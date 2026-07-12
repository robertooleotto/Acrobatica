// CGAL Region Growing sulla MESH (non sulla nuvola): cresce regioni planari
// seguendo la connettivita' dei triangoli + le normali. Deterministico, e non
// puo' piazzare piani nel vuoto (le regioni sono insiemi di facce adiacenti).
#include <CGAL/Exact_predicates_inexact_constructions_kernel.h>
#include <CGAL/Surface_mesh.h>
#include <CGAL/IO/polygon_mesh_io.h>
#include <CGAL/Shape_detection/Region_growing/Region_growing.h>
#include <CGAL/Shape_detection/Region_growing/Polygon_mesh.h>
#include <cmath>
#include <fstream>
#include <iostream>
#include <vector>

typedef CGAL::Exact_predicates_inexact_constructions_kernel Kernel;
typedef Kernel::Point_3  Point;
typedef Kernel::Vector_3 Vector;
typedef CGAL::Surface_mesh<Point> Mesh;
typedef Mesh::Face_index Face;

namespace SD = CGAL::Shape_detection::Polygon_mesh;
typedef SD::One_ring_neighbor_query<Mesh>                             Neighbor_query;
typedef SD::Least_squares_plane_fit_region<Kernel, Mesh>             Region_type;
typedef SD::Least_squares_plane_fit_sorting<Kernel, Mesh, Neighbor_query> Sorting;
typedef CGAL::Shape_detection::Region_growing<Neighbor_query, Region_type> Region_growing;

int main(int argc, char** argv) {
  if (argc < 2) { std::cerr << "uso: rg mesh.obj [maxd=0.05] [maxa=25] [minr=50]\n"; return 1; }
  const double maxd = argc > 2 ? atof(argv[2]) : 0.05;
  const double maxa = argc > 3 ? atof(argv[3]) : 25.0;
  const std::size_t minr = argc > 4 ? (std::size_t)atoi(argv[4]) : 50;

  Mesh mesh;
  if (!CGAL::IO::read_polygon_mesh(argv[1], mesh)) { std::cerr << "lettura fallita\n"; return 1; }
  std::cout << num_vertices(mesh) << " vertici, " << num_faces(mesh) << " facce\n";
  std::cout << "parametri: maxd=" << maxd << " m, maxa=" << maxa << " deg, minr=" << minr << "\n";

  // centroide + area di ogni faccia
  auto vpm = mesh.points();
  std::vector<Point> fc(num_faces(mesh));
  std::vector<double> fa(num_faces(mesh), 0.0);
  for (Face f : mesh.faces()) {
    std::vector<Point> p;
    for (auto v : vertices_around_face(mesh.halfedge(f), mesh)) p.push_back(vpm[v]);
    if (p.size() < 3) continue;
    fc[f] = CGAL::centroid(p[0], p[1], p[2]);
    fa[f] = std::sqrt(CGAL::squared_area(p[0], p[1], p[2]));
  }

  Neighbor_query nq(mesh);
  Region_type region_type(mesh, CGAL::parameters::maximum_distance(maxd)
                                    .maximum_angle(maxa).minimum_region_size(minr));
  Sorting sorting(mesh, nq);
  sorting.sort();
  Region_growing rg(faces(mesh), sorting.ordered(), nq, region_type);
  std::vector<Region_growing::Primitive_and_region> regions;
  rg.detect(std::back_inserter(regions));
  std::cout << regions.size() << " regioni planari\n\n";

  std::ofstream csv("faces.csv");
  csv << "face,cx,cy,cz,region\n";
  std::ofstream rcsv("regions.csv");
  rcsv << "region,nfaces,area,nx,ny,nz,cx,cy,cz\n";
  const Vector up(0, 1, 0);
  std::cout << "  reg   facce    area_m2   tilt(deg)  n=[x,y,z]\n";
  for (std::size_t r = 0; r < regions.size(); ++r) {
    Vector n = regions[r].first.orthogonal_vector();
    double L = std::sqrt(n * n); if (L > 0) n = n / L;
    double area = 0.0, cx = 0, cy = 0, cz = 0;
    for (Face f : regions[r].second) {
      area += fa[f];
      cx += fa[f] * fc[f].x(); cy += fa[f] * fc[f].y(); cz += fa[f] * fc[f].z();
      csv << static_cast<std::size_t>(f) << ","
          << fc[f].x() << "," << fc[f].y() << "," << fc[f].z() << "," << r << "\n";
    }
    if (area > 0) { cx /= area; cy /= area; cz /= area; }
    rcsv << r << "," << regions[r].second.size() << "," << area << ","
         << n.x() << "," << n.y() << "," << n.z() << ","
         << cx << "," << cy << "," << cz << "\n";
    double tilt = std::acos(std::min(1.0, std::fabs(n * up))) * 180.0 / M_PI;
    if (area >= 0.5)
      std::printf("  %3zu  %6zu  %9.2f   %7.1f    [%+.2f,%+.2f,%+.2f]\n",
                  r, regions[r].second.size(), area, tilt, n.x(), n.y(), n.z());
  }
  csv.close(); rcsv.close();
  std::cout << "\nscritto faces.csv + regions.csv\n";
  return 0;
}
